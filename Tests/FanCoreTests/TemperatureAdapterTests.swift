import Foundation
import Testing
import SiliconScopeCore
@testable import FanCore
@testable import FanHardware

struct TemperatureAdapterTests {
    @Test func libraryNamesAndKeysSurviveAndAverageLeads() {
        var sample = TemperatureSample()
        sample.cpuCelsius = 48.5
        sample.groups = [
            SiliconScopeCore.SensorGroup(category: .cpu, sensors: [
                TempSensor(rawName: "Tp09", name: "E-Core 1", celsius: 46),
                TempSensor(rawName: "Tp01", name: "P-Core 1", celsius: 51)
            ]),
            SiliconScopeCore.SensorGroup(category: .gpu, sensors: [
                TempSensor(rawName: "Tg05", name: "GPU 1", celsius: 43),
                TempSensor(rawName: "Tg0D", name: "GPU 2", celsius: 45)
            ]),
            SiliconScopeCore.SensorGroup(category: .memory, sensors: [
                TempSensor(rawName: "Tm02", name: "Memory 1", celsius: 40)
            ]),
            SiliconScopeCore.SensorGroup(category: .battery, sensors: [
                TempSensor(rawName: "TB1T", name: "Battery 1", celsius: 32)
            ])
        ]
        let readings = TemperatureAdapter.readings(from: sample, at: Date())
        #expect(readings.map(\.id) == [SensorCatalog.cpuAverageKey, SensorCatalog.gpuAverageKey,
                                       SensorCatalog.memoryAverageKey, SensorCatalog.batteryAverageKey,
                                       "Tp09", "Tp01", "Tg05", "Tg0D", "Tm02", "TB1T"])
        #expect(readings[4].name == "E-Core 1")
        #expect(readings[5].name == "P-Core 1")
        #expect(readings[9].name == "Battery 1")
        #expect(readings[0].celsius == 48.5)
        #expect(readings[1].celsius == 44)
        #expect(readings[2].celsius == 40)
        #expect(readings[3].celsius == 32)
    }

    @Test func noAverageWithoutLibraryCPUReading() {
        let readings = TemperatureAdapter.readings(from: TemperatureSample(), at: Date())
        #expect(readings.isEmpty)
    }
}
