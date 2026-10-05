import XCTest
@testable import Podium

/// The touchscreen controller's SPI protocol and touch reporting: frames
/// announced over ATN, collected as length + frame, with one record per
/// finger and the Make → Touching → Break → OutOfRange → empty lifecycle.
final class MultitouchN1Tests: XCTestCase {
    /// Drives one chip-select frame: clocks `command` out of the host
    /// while collecting what the controller clocks back, then deasserts
    /// CS so the controller answers that command. `clocks` pads short
    /// commands with idle clocks — a frame read clocks out the whole
    /// reply in one frame.
    @discardableResult
    private func transact(_ touch: MultitouchN1, _ command: [UInt8], clocks: Int = 16) -> [UInt8] {
        let padded = command + Array(repeating: UInt8(0), count: max(0, clocks - command.count))
        touch.chipSelectChanged(true)
        var reply: [UInt8] = []
        for byte in padded { reply.append(touch.exchange(byte)) }
        touch.chipSelectChanged(false)
        return reply
    }

    /// Puts the controller in firmware mode, the way the driver's firmware
    /// download ends (execute-downloaded-firmware).
    private func enterFirmware(_ touch: MultitouchN1) {
        transact(touch, [0x1D, 0x53])
    }

    /// Collects one announced frame the way the driver does: a stage-0
    /// read for the length, then a stage-1 read for the frame itself.
    /// Returns the frame bytes (header + records + checksum).
    private func collectFrame(_ touch: MultitouchN1, fingers: Int = 1) -> [UInt8] {
        transact(touch, [0xEA, 0x00, 0x00])
        let clocks = 8 + 24 + fingers * 28 + 8
        let collected = transact(touch, [0xEA, 0x00, 0x01], clocks: clocks)
        // Five header bytes summing to 0, then the frame, then its sum.
        let length = Int(collected[2]) | Int(collected[3]) << 8
        return Array(collected[5..<(5 + length - 2)])
    }

    private func header(of frame: [UInt8]) -> [UInt8] { Array(frame.prefix(24)) }
    private func records(of frame: [UInt8]) -> [[UInt8]] {
        let count = Int(header(of: frame)[16])
        return (0..<count).map { Array(frame[(24 + $0 * 28)..<(24 + ($0 + 1) * 28)]) }
    }

    func testBeganAssertsAttentionAndReportsMakeTouchAtCenter() {
        let touch = MultitouchN1()
        enterFirmware(touch)
        var attention: [Bool] = []
        touch.setAttention = { attention.append($0) }

        // Screen center: sensor (2500, 3750), Y flipped to bottom-left origin.
        touch.touch(.began, x: 0.5, y: 0.5, touchID: 0, time: 1000)

        XCTAssertEqual(attention, [true])
        let frame = collectFrame(touch)
        XCTAssertEqual(attention, [true, false])
        XCTAssertEqual(header(of: frame)[0], 0x44, "path frame")
        XCTAssertEqual(header(of: frame)[16], 1, "one finger")
        let record = records(of: frame)
        XCTAssertEqual(record.count, 1)
        XCTAssertEqual(record[0][0], 1, "path ID")
        XCTAssertEqual(record[0][1], 3, "MakeTouch")
        XCTAssertEqual(Int(record[0][4]) | Int(record[0][5]) << 8, 2500)
        XCTAssertEqual(Int(record[0][6]) | Int(record[0][7]) << 8, 3750)
    }

    func testTapLifecycleMakeBreakOutOfRangeThenEmpty() {
        let touch = MultitouchN1()
        enterFirmware(touch)
        touch.setAttention = { _ in }

        touch.touch(.began, x: 0.25, y: 0.75, touchID: 0, time: 1000)
        XCTAssertEqual(records(of: collectFrame(touch))[0][1], 3, "MakeTouch")

        touch.touch(.ended, x: 0.25, y: 0.75, touchID: 0, time: 1016)
        XCTAssertEqual(records(of: collectFrame(touch))[0][1], 5, "BreakTouch")

        // The controller's own scan advances the lifted path out of range,
        // then ends the gesture with a fingerless frame.
        touch.scan(time: 1033)
        XCTAssertEqual(records(of: collectFrame(touch))[0][1], 7, "OutOfRange")
        touch.scan(time: 1050)
        let last = collectFrame(touch)
        XCTAssertEqual(header(of: last)[16], 0, "empty frame ends the gesture")

        // Nothing left to report: the scan stays quiet.
        touch.scan(time: 1066)
        let idle = transact(touch, [0xEA, 0x00, 0x00])
        XCTAssertEqual(idle[0], 0xEA, "idle reply")
        XCTAssertEqual(idle[2], 0, "zero length: nothing left to say")
    }

    func testSecondFingerGetsItsOwnPathInsteadOfOverwriting() {
        let touch = MultitouchN1()
        enterFirmware(touch)
        touch.setAttention = { _ in }

        touch.touch(.began, x: 0.2, y: 0.2, touchID: 0, time: 1000)
        touch.touch(.began, x: 0.8, y: 0.8, touchID: 1, time: 1000)

        // Two begins queue two frames; the second carries both fingers.
        collectFrame(touch)
        let frame = collectFrame(touch, fingers: 2)
        let records = records(of: frame)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map { $0[0] }, [1, 2], "distinct path IDs")
        XCTAssertTrue(records.allSatisfy { $0[1] == 3 || $0[1] == 4 })
        // First finger kept its position: x 0.2 * 5000 = 1000.
        XCTAssertEqual(Int(records[0][4]) | Int(records[0][5]) << 8, 1000)
    }

    func testMoveAndLiftOfUnknownFingerReportNothing() {
        let touch = MultitouchN1()
        enterFirmware(touch)
        var attentionCount = 0
        touch.setAttention = { if $0 { attentionCount += 1 } }

        touch.touch(.moved, x: 0.5, y: 0.5, touchID: 0, time: 1000)
        touch.touch(.ended, x: 0.5, y: 0.5, touchID: 9, time: 1000)

        XCTAssertEqual(attentionCount, 0, "no frame announced")
        let reply = transact(touch, [0xEA, 0x00, 0x00])
        XCTAssertEqual(Array(reply.prefix(3)), [0xEA, 0x00, 0x00], "idle reply, no length")
    }

    func testTouchesBeforeFirmwareAreDropped() {
        let touch = MultitouchN1()
        var attentionCount = 0
        touch.setAttention = { if $0 { attentionCount += 1 } }

        touch.touch(.began, x: 0.5, y: 0.5, touchID: 0, time: 1000)
        XCTAssertEqual(attentionCount, 0, "bootloader reports no touches")
    }

    func testResetForgetsFingersAndReleasesAttention() {
        let touch = MultitouchN1()
        enterFirmware(touch)
        var attention: [Bool] = []
        touch.setAttention = { attention.append($0) }

        touch.touch(.began, x: 0.5, y: 0.5, touchID: 0, time: 1000)
        XCTAssertEqual(attention, [true])
        touch.reset()
        XCTAssertEqual(attention, [true, false])

        // The pre-reset finger is gone: its lift reports nothing.
        touch.touch(.ended, x: 0.5, y: 0.5, touchID: 0, time: 1016)
        XCTAssertEqual(attention, [true, false])
    }

    func testQueuedFramesAreCappedWhenTheDriverStopsReading() {
        let touch = MultitouchN1()
        enterFirmware(touch)
        touch.setAttention = { _ in }

        touch.touch(.began, x: 0.5, y: 0.5, touchID: 0, time: 1000)
        for i in 1...100 {
            touch.touch(.moved, x: 0.5, y: 0.5, touchID: 0, time: 1000 + UInt32(i))
        }

        // Drain everything the controller queued; it must stop at the cap
        // instead of holding all 101 frames.
        var collected = 0
        for _ in 0..<120 {
            transact(touch, [0xEA, 0x00, 0x00])
            let reply = transact(touch, [0xEA, 0x00, 0x01], clocks: 64)
            guard reply[0] == 0xEA, reply[2] != 0 || reply[3] != 0 else { break }
            let length = Int(reply[2]) | Int(reply[3]) << 8
            if length > 2 { collected += 1 }
        }
        XCTAssertEqual(collected, 32, "queue capped, newest state kept")
    }
}
