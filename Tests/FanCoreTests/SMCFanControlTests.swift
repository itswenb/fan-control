import Testing
@testable import FanCore

struct SMCFanControlTests {
    let floatTarget: SMCFanControl.Value = ("flt ", [0, 0, 0, 0])
    let automatic: SMCFanControl.Value = ("ui8 ", [0])

    @Test func directModesRecognizeBothKeySpellingsAndAutomaticModeThree() throws {
        for key in ["F0md", "F0Md"] {
            let values = ["F0Tg": floatTarget, key: automatic]
            let control = try #require(SMCFanControl.discover(fanID: "F0") { values[$0] })
            #expect(control.modeKey == key)
            #expect(control.mode(from: ("ui8 ", [3])) == .automatic)
            #expect(control.mode(from: ("ui8 ", [1])) == .fixed)
            #expect(control.mode(from: ("ui8 ", [2])) == nil)
            let bytes = try #require(control.targetBytes(rpm: 5_779))
            #expect(SMCCodec.decode(type: "flt ", bytes: bytes) == 5_779)
            #expect(control.supports(range: 0...6_000))
        }
    }

    @Test func fpe2EncodingRejectsOverflowAndKeepsQuarterRPMPrecision() throws {
        let values: [String: SMCFanControl.Value] = ["F2Tg": ("fpe2", [0, 0]), "F2Md": automatic]
        let control = try #require(SMCFanControl.discover(fanID: "F2") { values[$0] })
        #expect(control.targetBytes(rpm: 2_000) == [0x1f, 0x40])
        let bytes = try #require(control.targetBytes(rpm: 2_000.13))
        #expect(SMCCodec.decode(type: "fpe2", bytes: bytes) == 2_000.25)
        #expect(control.targetBytes(rpm: 16_383.75) == [255, 255])
        for rpm in [-1.0, .nan, .infinity, 16_384, 30_001] {
            #expect(control.targetBytes(rpm: rpm) == nil)
        }
        #expect(control.supports(range: 0...6_000))
        #expect(!control.supports(range: 1_200...20_000))
    }

    @Test func unrecognizedOrDamagedInterfacesRemainReadOnly() {
        let invalid: [[String: SMCFanControl.Value]] = [
            ["F0Tg": floatTarget],
            ["F0Tg": ("ui16", [0, 0]), "F0md": automatic],
            ["F0Tg": ("flt ", [0, 0]), "F0md": automatic],
            ["F0Tg": ("flt ", [0, 0, 128, 127]), "F0md": automatic],
            ["F0Tg": floatTarget, "F0md": ("ui8 ", [2])],
            ["F0Tg": floatTarget, "F0md": ("ui16", [0, 0])],
            ["F0Tg": floatTarget, "FS! ": ("ui16", [0, 0])]
        ]
        for values in invalid {
            #expect(SMCFanControl.discover(fanID: "F0") { values[$0] } == nil)
        }
        for id in ["F", "F00", "FG", "Fa", "T0", "FS! "] {
            #expect(SMCFanControl.fanIndex(id) == nil)
            var readCount = 0
            #expect(SMCFanControl.discover(fanID: id) { _ in readCount += 1; return automatic } == nil)
            #expect(readCount == 0)
        }
        #expect(SMCFanControl.fanIndex("FF") == 15)
    }
}
