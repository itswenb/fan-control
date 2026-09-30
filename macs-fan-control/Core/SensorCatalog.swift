import Foundation

/// 仅保留应用自身的合成测点。真实温度测点的名称和分类由 SiliconScopeCore 提供。
public enum SensorCatalog {
    public static let cpuAverageKey = "__cpuAvg"
    public static let gpuAverageKey = "__gpuAvg"
    public static let memoryAverageKey = "__memoryAvg"
    public static let batteryAverageKey = "__batteryAvg"
    private static let averageKeys = [cpuAverageKey, gpuAverageKey, memoryAverageKey, batteryAverageKey]

    public static func averageRank(key: String) -> Int? { averageKeys.firstIndex(of: key) }

    public static func fanName(id: String, model: String, english: Bool) -> String? {
        guard model == "MacBookPro18,3" else { return nil }
        switch id {
        case "F0": return english ? "Left fan" : "左侧风扇"
        case "F1": return english ? "Right fan" : "右侧风扇"
        default: return nil
        }
    }

    public static func syntheticName(key: String, english: Bool) -> String? {
        switch key {
        case cpuAverageKey: return english ? "CPU · Average temperature" : "CPU · 平均温度"
        case gpuAverageKey: return english ? "GPU · Average temperature" : "GPU · 平均温度"
        case memoryAverageKey: return english ? "Memory · Average temperature" : "内存 · 平均温度"
        case batteryAverageKey: return english ? "Battery · Average temperature" : "电池 · 平均温度"
        default: return nil
        }
    }
}
