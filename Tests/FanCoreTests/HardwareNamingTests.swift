import Testing
@testable import FanCore

struct HardwareNamingTests {
    @Test func knownFanPositionsNeverLeakToUnknownModels() {
        #expect(SensorCatalog.fanName(id: "F0", model: "MacBookPro18,3", english: false) == "左侧风扇")
        #expect(SensorCatalog.fanName(id: "F1", model: "MacBookPro18,3", english: true) == "Right fan")
        #expect(SensorCatalog.fanName(id: "F0", model: "UnknownMac", english: true) == nil)
        #expect(SensorCatalog.syntheticName(key: SensorCatalog.cpuAverageKey, english: false) == "CPU · 平均温度")
        #expect(SensorCatalog.syntheticName(key: "Tp0P", english: false) == nil)
    }

    @Test func signingHashesRejectRequirementInjectionAndMalformedValues() {
        #expect(CodeIdentity.validHash(String(repeating: "a1", count: 20)))
        #expect(!CodeIdentity.validHash("any"))
        #expect(!CodeIdentity.validHash(String(repeating: "g", count: 40)))
        #expect(!CodeIdentity.validHash("\" or true"))
        #expect(!CodeIdentity.validHash(String(repeating: "1", count: 39)))
    }
}
