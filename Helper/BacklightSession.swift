import CoreGraphics
import Darwin
import Foundation
import IOKit
import FanCore

@objc private protocol KeyboardIDs {
    func copyKeyboardBacklightIDs() -> [NSNumber]?
    @objc(isKeyboardBuiltIn:) func isKeyboardBuiltIn(_ id: UInt64) -> Bool
}

@objc private protocol KeyboardLight {
    @objc(copyPropertyForKey:keyboardID:) func copyProperty(forKey key: String, keyboardID: UInt64) -> Any?
    @objc(setProperty:withKey:keyboardID:) func setProperty(_ value: Any, withKey key: String, keyboardID: UInt64) -> Bool
}

/// 用户态短连接：退出时让系统取回键盘自动亮度。 / A short-lived user process relinquishes brightness ownership on exit.
enum BacklightSession {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.count == 2,
              ["--backlight-probe", "--backlight-session"].contains(CommandLine.arguments[1]) else { return false }
        let diagnostics = SleepDiagnosticLog.application
        diagnostics.event("backlight", "process.start", "mode=\(CommandLine.arguments[1]) OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        do {
            let lights = try Lights()
            if CommandLine.arguments[1] == "--backlight-probe" {
                diagnostics.event("backlight", "probe.ready")
                FileHandle.standardOutput.write(Data("ready\n".utf8))
                return true
            }
            guard lidClosed() == true else {
                diagnostics.event("backlight", "session.skip", "lid no longer closed")
                FileHandle.standardOutput.write(Data("ready\n".utf8))
                return true
            }
            var success = true
            do {
                try lights.darken()
                FileHandle.standardOutput.write(Data("ready\n".utf8))
                while lidClosed() == true {
                    var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
                    let result = poll(&input, 1, 4_000)
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else {
                        diagnostics.event("backlight", "session.end", "poll=\(result) errno=\(errno) reason=heartbeat_timeout_or_poll_error", error: result < 0)
                        break
                    }
                    var byte: UInt8 = 0
                    let received = read(STDIN_FILENO, &byte, 1)
                    guard received == 1 else {
                        diagnostics.event("backlight", "session.end", "read=\(received) errno=\(errno) reason=parent_pipe_closed")
                        break
                    }
                    try lights.darken()
                }
                diagnostics.event("backlight", "session.loop_finished", "lidClosed=\(String(describing: lidClosed()))")
            } catch {
                diagnostics.event("backlight", "darken.failed", SleepDiagnosticLog.describe(error), error: true)
                success = false
            }
            if !lights.restore() { success = false }
            diagnostics.event("backlight", "process.exit", "status=\(success ? 0 : 1); releasing brightness clients", error: !success)
            if !success { exit(1) }
        } catch {
            diagnostics.event("backlight", "initialize.failed", SleepDiagnosticLog.describe(error), error: true)
            FileHandle.standardError.write(Data((SleepDiagnosticLog.describe(error) + "\n").utf8))
            exit(1)
        }
        return true
    }

    private static func lidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.boolValue
    }

    private final class Lights {
        private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
        private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
        private let getDisplay: GetBrightness
        private let setDisplay: SetBrightness
        private let display: CGDirectDisplayID
        private let keyboard: any KeyboardLight
        private let keyboardObject: NSObject
        private let keyboardID: UInt64
        private let displayBrightness: Float
        private let keyboardBrightness: Float
        private var displayTouched = false
        private var keyboardTouched = false
        private var confirmedDark = false
        private let key = "KeyboardBacklightBrightness"

        init() throws {
            guard let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) else { throw BacklightError.unavailable("dlopen DisplayServices") }
            guard let getter = dlsym(framework, "DisplayServicesGetBrightness") else { throw BacklightError.unavailable("symbol DisplayServicesGetBrightness") }
            guard let setter = dlsym(framework, "DisplayServicesSetBrightness") else { throw BacklightError.unavailable("symbol DisplayServicesSetBrightness") }
            guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil else { throw BacklightError.unavailable("dlopen CoreBrightness") }
            guard let keyboardClass = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { throw BacklightError.unavailable("class KeyboardBrightnessClient") }
            guard let brightnessClass = NSClassFromString("BrightnessSystemClient") as? NSObject.Type else { throw BacklightError.unavailable("class BrightnessSystemClient") }
            getDisplay = unsafeBitCast(getter, to: GetBrightness.self)
            setDisplay = unsafeBitCast(setter, to: SetBrightness.self)
            var displays = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
            let displayResult = CGGetOnlineDisplayList(16, &displays, &count)
            guard displayResult == .success,
                  let builtin = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { throw BacklightError.unavailable("CGGetOnlineDisplayList result=\(displayResult.rawValue) count=\(count); built-in display missing") }
            display = builtin
            var level: Float = 0
            let readResult = getDisplay(display, &level)
            guard readResult == 0, level.isFinite, (0...1).contains(level) else { throw BacklightError.unavailable("DisplayServicesGetBrightness result=\(readResult) value=\(level)") }
            displayBrightness = level
            let idsObject = keyboardClass.init()
            keyboardObject = brightnessClass.init()
            for selector in ["copyKeyboardBacklightIDs", "isKeyboardBuiltIn:"] {
                guard idsObject.responds(to: NSSelectorFromString(selector)) else { throw BacklightError.unavailable("KeyboardBrightnessClient selector=\(selector)") }
            }
            for selector in ["copyPropertyForKey:keyboardID:", "setProperty:withKey:keyboardID:"] {
                guard keyboardObject.responds(to: NSSelectorFromString(selector)) else { throw BacklightError.unavailable("BrightnessSystemClient selector=\(selector)") }
            }
            let ids = unsafeBitCast(idsObject, to: (any KeyboardIDs).self)
            guard let id = ids.copyKeyboardBacklightIDs()?.first(where: { ids.isKeyboardBuiltIn($0.uint64Value) }) else { throw BacklightError.unavailable("copyKeyboardBacklightIDs / isKeyboardBuiltIn: no built-in keyboard") }
            keyboardID = id.uint64Value
            keyboard = unsafeBitCast(keyboardObject, to: (any KeyboardLight).self)
            guard let brightness = keyboard.copyProperty(forKey: key, keyboardID: keyboardID) as? NSNumber,
                  brightness.floatValue.isFinite, (0...1).contains(brightness.floatValue) else { throw BacklightError.unavailable("copyPropertyForKey KeyboardBacklightBrightness invalid") }
            keyboardBrightness = brightness.floatValue
            SleepDiagnosticLog.application.event("backlight", "initial.readings", "displayID=\(display) brightness=\(displayBrightness) keyboardID=\(keyboardID) brightness=\(keyboardBrightness)")
        }

        func darken() throws {
            var brightness: Float = 0
            let readResult = getDisplay(display, &brightness)
            guard readResult == 0 else { throw BacklightError.unavailable("DisplayServicesGetBrightness result=\(readResult)") }
            if brightness > 0 {
                displayTouched = true
                let result = setDisplay(display, 0)
                SleepDiagnosticLog.application.event("backlight", "display.write", "before=\(brightness) requested=0 result=\(result)", error: result != 0)
                guard result == 0 else { throw BacklightError.unavailable("DisplayServicesSetBrightness result=\(result)") }
            }
            guard let value = keyboard.copyProperty(forKey: key, keyboardID: keyboardID) as? NSNumber else { throw BacklightError.unavailable("keyboard brightness property missing during readback") }
            if value.floatValue > 0 {
                keyboardTouched = true
                let written = keyboard.setProperty(NSNumber(value: Float(0)), withKey: key, keyboardID: keyboardID)
                SleepDiagnosticLog.application.event("backlight", "keyboard.write", "before=\(value) requested=0 accepted=\(written)", error: !written)
                guard written else { throw BacklightError.unavailable("BrightnessSystemClient setProperty rejected") }
            }
            let confirmed = getDisplay(display, &brightness)
            let keyboardLevel = (keyboard.copyProperty(forKey: key, keyboardID: keyboardID) as? NSNumber)?.floatValue
            guard confirmed == 0, brightness == 0, keyboardLevel == 0 else {
                throw BacklightError.unavailable("zero readback displayResult=\(confirmed) display=\(brightness) keyboard=\(String(describing: keyboardLevel))")
            }
            if !confirmedDark {
                SleepDiagnosticLog.application.event("backlight", "zero.confirmed", "display=\(brightness) keyboard=\(String(describing: keyboardLevel))")
                confirmedDark = true
            }
        }

        func restore() -> Bool {
            var restored = true
            if displayTouched {
                let result = setDisplay(display, displayBrightness)
                var actual: Float = 0
                let readResult = getDisplay(display, &actual)
                SleepDiagnosticLog.application.event("backlight", "display.restore", "requested=\(displayBrightness) result=\(result) readResult=\(readResult) actual=\(actual)", error: result != 0 || readResult != 0)
                restored = result == 0
            }
            if keyboardTouched {
                let keyboardRestored = keyboard.setProperty(NSNumber(value: keyboardBrightness), withKey: key, keyboardID: keyboardID)
                let actual = (keyboard.copyProperty(forKey: key, keyboardID: keyboardID) as? NSNumber)?.floatValue
                SleepDiagnosticLog.application.event("backlight", "keyboard.restore", "requested=\(keyboardBrightness) accepted=\(keyboardRestored) actual=\(String(describing: actual))", error: !keyboardRestored)
                restored = restored && keyboardRestored
            }
            return restored
        }
    }

    private enum BacklightError: Error, LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let stage): "Backlight interface failed: " + stage }
        }
    }
}
