import CryptoKit
import Foundation

// Sparkle 2.10 支持以 Base64 编码的 32 字节 Ed25519 私钥种子，无需访问钥匙串。
let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments == ["generate"] {
        let directory = URL(fileURLWithPath: ".secrets", isDirectory: true)
        let file = directory.appendingPathComponent("sparkle.key")
        guard !FileManager.default.fileExists(atPath: file.path) else {
            throw NSError(domain: "FanControlUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "私钥已存在，拒绝覆盖。请备份并继续使用原密钥。"])
        }
        let key = Curve25519.Signing.PrivateKey()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: file.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                            attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let configuration = """
        // 公钥可公开；对应的私钥只能保存在本机或 GitHub Actions Secrets。
        INFOPLIST_KEY_SUPublicEDKey = \(publicKey)
        INFOPLIST_KEY_SUFeedURL = https:/$()/github.com/itswenb/fan-control/releases/latest/download/appcast.xml
        // 无 Developer ID 的构建采用 ad hoc 签名，避免第三方框架的 Team ID 验证失败。
        ENABLE_HARDENED_RUNTIME = NO

        """
        try FileManager.default.createDirectory(atPath: "Configuration", withIntermediateDirectories: true)
        try configuration.write(toFile: "Configuration/Updates.xcconfig", atomically: true, encoding: .utf8)
        print("公钥配置已生成：Configuration/Updates.xcconfig")
        print("私钥已保存：.secrets/sparkle.key（不会打印或提交，请安全备份）")
    } else if arguments.count == 2, arguments[0] == "public" {
        let text = try String(contentsOfFile: arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seed = Data(base64Encoded: text), seed.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        print(key.publicKey.rawRepresentation.base64EncodedString())
    } else {
        throw NSError(domain: "FanControlUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "用法：swift scripts/update-key.swift generate | public <私钥文件>"])
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
