import Foundation

public struct PresetRepository: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    private struct Document: Codable {
        var version = 1
        var presets: [FanPreset]
    }

    public func load() throws -> [FanPreset] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 1, document.presets.count <= 200,
                  Set(document.presets.map(\.id)).count == document.presets.count else { throw ControlError.invalidConfiguration }
            for preset in document.presets {
                _ = try Self.validatedName(preset.name)
                guard !preset.policies.isEmpty, Set(preset.policies.map(\.fanID)).count == preset.policies.count else {
                    throw ControlError.invalidConfiguration
                }
            }
            return document.presets
        } catch { throw ControlError.invalidConfiguration }
    }

    public func save(_ presets: [FanPreset]) throws {
        // 不覆盖无法理解的文件；只有用户明确恢复后才重建。
        _ = try load()
        guard presets.count <= 200 else { throw ControlError.invalidConfiguration }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(presets: presets))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count) else { throw ControlError.invalidName }
        return name
    }

    public static func checkUnique(_ name: String, in presets: [FanPreset], excluding id: UUID? = nil) throws {
        guard !presets.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw ControlError.duplicateName
        }
    }
}
