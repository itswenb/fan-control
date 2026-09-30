import Foundation
import FanCore
import FanHardware

// 只读探测工具，没有写入子命令。便于记录 M0 兼容性证据。
let reader = SMCReader()
do {
    var snapshot = try await reader.sample()
    for _ in 0..<24 {
        snapshot = try await reader.sample()
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(snapshot)
    print(String(decoding: data, as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
