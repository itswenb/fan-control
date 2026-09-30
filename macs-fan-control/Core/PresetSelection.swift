import Foundation

public enum PresetSelection: Equatable, Sendable {
    case automatic, fullSpeed, custom, preset(UUID)

    /// 服务策略包含实际调速规则；预设中显式保存的自动风扇和无关编辑字段不影响匹配。
    public static func resolve(policies: [FanPolicy], in snapshot: HardwareSnapshot,
                               presets: [FanPreset], preferredID: UUID? = nil, preferFullSpeed: Bool = false) -> Self {
        let rules = normalized(policies)
        let matches = presets.filter {
            $0.model == snapshot.model && $0.source == snapshot.source && normalized($0.policies) == rules
        }
        guard !rules.isEmpty else {
            if let preferred = matches.first(where: { $0.id == preferredID }) { return .preset(preferred.id) }
            return .automatic
        }
        let full = snapshot.fans.filter(\.controlSupported).compactMap { fan -> FanPolicy? in
            guard let range = fan.validRange else { return nil }
            return FanPolicy(fanID: fan.id, mode: .fixed, rpm: range.upperBound)
        }
        let isFull = !full.isEmpty && rules == normalized(full)
        if preferFullSpeed && isFull { return .fullSpeed }
        if let preferred = matches.first(where: { $0.id == preferredID }) { return .preset(preferred.id) }
        if let first = matches.first { return .preset(first.id) }
        return isFull ? .fullSpeed : .custom
    }

    private static func normalized(_ policies: [FanPolicy]) -> [FanPolicy] {
        policies.compactMap { policy -> FanPolicy? in
            switch policy.mode {
            case .automatic: return nil
            case .fixed: return FanPolicy(fanID: policy.fanID, mode: .fixed, rpm: policy.rpm)
            case .sensor: return FanPolicy(fanID: policy.fanID, mode: .sensor, sensorID: policy.sensorID, low: policy.low, high: policy.high)
            }
        }.sorted { $0.fanID < $1.fanID }
    }
}
