import Foundation
import SiliconScopeCore
#if SWIFT_PACKAGE
import FanCore
#endif

/// 保留库返回的真实测点名称和 ID，仅增加四个分组平均温度。
public enum TemperatureAdapter {
    public static func readings(from sample: TemperatureSample, at now: Date) -> [SensorReading] {
        var result: [SensorReading] = []
        let averages: [(SensorCategory, String, FanCoreSensorGroup)] = [
            (.cpu, SensorCatalog.cpuAverageKey, .cpu),
            (.gpu, SensorCatalog.gpuAverageKey, .gpu),
            (.memory, SensorCatalog.memoryAverageKey, .memory),
            (.battery, SensorCatalog.batteryAverageKey, .battery)
        ]
        for (category, key, appGroup) in averages {
            guard let group = sample.groups.first(where: { $0.category == category }), !group.sensors.isEmpty else { continue }
            result.append(SensorReading(
                id: key,
                name: SensorCatalog.syntheticName(key: key, english: false) ?? "",
                group: appGroup,
                celsius: group.average,
                sampledAt: now
            ))
        }
        for group in sample.groups {
            for sensor in group.sensors {
                let category: FanCoreSensorGroup
                switch group.category {
                case .cpu: category = .cpu
                case .gpu: category = .gpu
                case .memory: category = .memory
                case .battery: category = .battery
                case .other: category = .other
                }
                result.append(SensorReading(id: sensor.rawName, name: sensor.name, group: category,
                                            celsius: sensor.celsius, sampledAt: now))
            }
        }
        return result
    }
}

#if SWIFT_PACKAGE
private typealias FanCoreSensorGroup = FanCore.SensorGroup
#else
private typealias FanCoreSensorGroup = SensorGroup
#endif
