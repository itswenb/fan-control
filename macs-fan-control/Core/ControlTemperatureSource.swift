import Foundation

/// 只传递库已识别的测点 ID，温度值仍由服务独立读取，不信任客户端缓存值。
public struct ControlTemperatureSource: Codable, Sendable, Equatable {
    public let id: String
    public let group: SensorGroup
    public let keys: [String]

    public init(id: String, group: SensorGroup, keys: [String]) {
        self.id = id; self.group = group; self.keys = keys
    }

    public static func resolve(_ policies: [FanPolicy], in snapshot: HardwareSnapshot) throws -> [Self] {
        let ids = Set(policies.filter { $0.mode == .sensor }.compactMap(\.sensorID))
        return try ids.sorted().map { id in
            guard let sensor = snapshot.sensors.first(where: { $0.id == id }) else { throw ControlError.missingSensor }
            let keys = SensorCatalog.averageRank(key: id) == nil ? [id] : snapshot.sensors
                .filter { $0.group == sensor.group && SensorCatalog.averageRank(key: $0.id) == nil }
                .map(\.id).sorted()
            guard !keys.isEmpty else { throw ControlError.missingSensor }
            return Self(id: id, group: sensor.group, keys: keys)
        }
    }

    public static func validate(_ sources: [Self], for policies: [FanPolicy]) throws {
        let requested = policies.filter { $0.mode == .sensor }
        guard requested.allSatisfy({ $0.sensorID != nil }), sources.count <= 16,
              Set(sources.map(\.id)).count == sources.count,
              Set(sources.map(\.id)) == Set(requested.compactMap(\.sensorID)) else { throw ControlError.missingSensor }
        guard Set(sources.flatMap(\.keys)).count <= 256 else { throw ControlError.invalidConfiguration }
        for source in sources {
            guard (1...128).contains(source.id.utf8.count), (1...128).contains(source.keys.count),
                  Set(source.keys).count == source.keys.count,
                  source.keys.allSatisfy({ (1...128).contains($0.utf8.count) && SensorCatalog.averageRank(key: $0) == nil }),
                  SensorCatalog.averageRank(key: source.id) != nil || source.keys == [source.id] else {
                throw ControlError.invalidConfiguration
            }
        }
    }
}
