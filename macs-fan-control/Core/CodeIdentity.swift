import Foundation
import Security
import Darwin

public struct CodeIdentity: Codable, Equatable, Sendable {
    public let identifier: String
    public let hash: String

    public static let executionArchitecture = "arm64"

    public var requirement: String { "identifier \"\(identifier)\" and cdhash H\"\(hash)\"" }

    /// cdhash 属于单个架构，不能让 codesign 将它同时用于通用文件中的所有架构。
    public var verificationArguments: [String] {
        ["--verify", "--strict", "--arch", Self.executionArchitecture, "-R=" + requirement]
    }

    public static func read(at url: URL, identifier: String) throws -> CodeIdentity {
        var code: SecStaticCode?
        let attributes = [kSecCodeAttributeArchitecture as String: executionArchitecture] as CFDictionary
        guard SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes, &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess else { throw ControlError.invalidSignature }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], values[kSecCodeInfoIdentifier as String] as? String == identifier,
              let hash = values[kSecCodeInfoUnique as String] as? Data, hash.count == 20 else { throw ControlError.invalidSignature }
        return CodeIdentity(identifier: identifier, hash: hash.map { String(format: "%02x", $0) }.joined())
    }

    public func validateRunningProcess() throws {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(self.requirement as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw ControlError.invalidSignature }
    }

    public static func validHash(_ hash: String) -> Bool {
        hash.count == 40 && hash.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

public struct InstalledTrust: Codable, Sendable {
    public var version = 1
    public let client: CodeIdentity
    public let helper: CodeIdentity
    public init(client: CodeIdentity, helper: CodeIdentity) { self.client = client; self.helper = helper }

    public static func read() throws -> InstalledTrust {
        let descriptor = open(HelperConstants.trustPath, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ControlError.invalidSignature }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o022 == 0,
              metadata.st_size > 0, metadata.st_size <= 4096 else { throw ControlError.invalidSignature }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let value = try JSONDecoder().decode(InstalledTrust.self, from: handle.readToEnd() ?? Data())
        guard value.version == 1, value.client.identifier == HelperConstants.appIdentifier,
              value.helper.identifier == HelperConstants.machService,
              CodeIdentity.validHash(value.client.hash), CodeIdentity.validHash(value.helper.hash) else { throw ControlError.invalidSignature }
        return value
    }
}
