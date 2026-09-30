import Foundation
import Testing
@testable import FanCore

struct CodeIdentityTests {
    /// 重现管理员安装器的复制与签名校验，不注册服务，也不访问硬件。
    @Test func copiedAppAndHelperSatisfyTheirPinnedRequirements() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Original.app")
        let contents = app.appendingPathComponent("Contents")
        let executables = contents.appendingPathComponent("MacOS")
        let helpers = contents.appendingPathComponent("Library/HelperTools")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fixture.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let executable = executables.appendingPathComponent("Fixture")
        #expect(try run("/usr/bin/xcrun", ["clang", "-arch", "arm64", "-mmacosx-version-min=14.0", source.path, "-o", executable.path]) == 0)
        let helper = helpers.appendingPathComponent("FanControlHelper")
        try FileManager.default.copyItem(at: executable, to: helper)
        let plist: [String: Any] = ["CFBundleIdentifier": HelperConstants.appIdentifier,
                                    "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        #expect(try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", HelperConstants.machService, helper.path]) == 0)
        #expect(try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) == 0)
        let clientIdentity = try CodeIdentity.read(at: app, identifier: HelperConstants.appIdentifier)
        let helperIdentity = try CodeIdentity.read(at: helper, identifier: HelperConstants.machService)
        let stagedApp = root.appendingPathComponent("Staged.app")
        #expect(try run("/usr/bin/ditto", [app.path, stagedApp.path]) == 0)
        let stagedHelper = stagedApp.appendingPathComponent("Contents/Library/HelperTools/FanControlHelper")
        #expect(try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path]) == 0)
        #expect(try run("/usr/bin/codesign", clientIdentity.verificationArguments + [stagedApp.path]) == 0)
        #expect(try run("/usr/bin/codesign", helperIdentity.verificationArguments + [stagedHelper.path]) == 0)
        #expect(try CodeIdentity.read(at: stagedApp, identifier: HelperConstants.appIdentifier) == clientIdentity)
        #expect(try CodeIdentity.read(at: stagedHelper, identifier: HelperConstants.machService) == helperIdentity)
        #expect(throws: ControlError.invalidSignature) { try CodeIdentity.read(at: stagedHelper, identifier: HelperConstants.appIdentifier) }
        let wrongHash = CodeIdentity(identifier: clientIdentity.identifier, hash: String(repeating: "0", count: 40))
        #expect(try run("/usr/bin/codesign", wrongHash.verificationArguments + [stagedApp.path]) != 0)
        let file = try FileHandle(forWritingTo: stagedHelper)
        try file.seek(toOffset: 0)
        try file.write(contentsOf: Data([0]))
        try file.close()
        #expect(throws: ControlError.invalidSignature) { try CodeIdentity.read(at: stagedApp, identifier: HelperConstants.appIdentifier) }
    }

    private func run(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
