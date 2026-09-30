#if DEBUG
import AppKit
import SwiftUI

/// 本地界面检查入口，仅 Debug 编译，使用真实只读采样，不应用任何策略。
@MainActor
enum DebugPreview {
    static func captureIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--capture-preview"), arguments.indices.contains(index + 1) else { return false }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        Task {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let defaults = UserDefaults(suiteName: "FanControl.Preview.\(UUID().uuidString)")!
                let storage = directory.appendingPathComponent("preview-state-\(UUID().uuidString)")
                let store = AppStore(defaults: defaults, storageDirectory: storage)
                let reader = SMCReader()
                for _ in 0..<25 { store.snapshot = try await reader.sample() }
                store.now = Date(); store.isLoading = false
                store.settings.language = .chinese
                try await capture(ContentView().environment(store), name: "monitor-light", size: NSSize(width: 900, height: 560), appearance: .aqua, directory: directory)
                store.settings.language = .english
                try await capture(ContentView().environment(store), name: "monitor-dark", size: NSSize(width: 860, height: 480), appearance: .darkAqua, directory: directory)
                guard let fan = store.snapshot?.fans.first else { throw ControlError.missingFan }
                for mode in FanMode.allCases {
                    store.snapshot = try await reader.sample(); store.now = Date()
                    let height: CGFloat = switch mode {
                    case .automatic: 300
                    case .fixed: 375
                    case .sensor: 468
                    }
                    try await capture(FanEditorView(fan: fan, initialMode: mode).environment(store), name: "editor-" + mode.rawValue, size: NSSize(width: 560, height: height), appearance: .aqua, directory: directory)
                }
                try await capture(FanEditorView(fan: fan, initialMode: .sensor).environment(store), name: "editor-sensor-dark", size: NSSize(width: 560, height: 468), appearance: .darkAqua, directory: directory)
                store.settings.language = .chinese
                try await capture(FanEditorView(fan: fan, initialMode: .sensor).environment(store), name: "editor-sensor-zh", size: NSSize(width: 560, height: 468), appearance: .aqua, directory: directory)
                store.settings.language = .english
                try await capture(PresetsView().environment(store), name: "presets", size: NSSize(width: 690, height: 470), appearance: .aqua, directory: directory)
                try await capture(SettingsView().environment(store), name: "settings", size: NSSize(width: 510, height: 660), appearance: .aqua, directory: directory)
                store.snapshot = try await reader.sample(); store.now = Date()
                try await capture(MenuBarView().environment(store), name: "menu", size: NSSize(width: 340, height: 340), appearance: .aqua, directory: directory)
                let legacyIcon = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"menuDisplay":"icon","sensorID":"Tp01"}"#.utf8))
                guard legacyIcon.menuDisplay == .none, legacyIcon.showMenuIcon, legacyIcon.sensorID == "Tp01" else { throw ControlError.invalidConfiguration }
                store.settings.showMenuIcon = false
                store.settings.menuDisplay = .temperature
                guard store.menuLines.count == 1, store.menuTitle.contains(store.settings.unit.symbol) else { throw ControlError.invalidConfiguration }
                try await capture(MenuBarStatusLabel().environment(store), name: "menu-status-temperature", size: NSSize(width: 160, height: 26), appearance: .aqua, directory: directory)
                store.settings.showMenuIcon = true
                store.settings.menuDisplay = .both
                guard store.menuLines.count == 2, store.menuLines[1].hasSuffix("RPM") else { throw ControlError.invalidConfiguration }
                try await capture(MenuBarStatusLabel().environment(store), name: "menu-status-both", size: NSSize(width: 160, height: 26), appearance: .aqua, directory: directory)
                store.settings.menuDisplay = .none
                guard store.menuLines.isEmpty else { throw ControlError.invalidConfiguration }
                try await capture(MenuBarStatusLabel().environment(store), name: "menu-status-icon", size: NSSize(width: 60, height: 26), appearance: .aqua, directory: directory)
                try await capture(FullSpeedSheet().environment(store), name: "full-speed", size: NSSize(width: 448, height: 320), appearance: .aqua, directory: directory)
                try await capture(ControlSetupView().environment(store), name: "control-setup", size: NSSize(width: 508, height: 430), appearance: .aqua, directory: directory)
                let client = try CodeIdentity.read(at: Bundle.main.bundleURL, identifier: HelperConstants.appIdentifier)
                try client.validateRunningProcess()
                store.stop()
                try "Real read-only UI render, menu status text, and running application signature checks passed. No hardware writes performed.\n".write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? error.localizedDescription.write(to: directory.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
            }
            NSApp.terminate(nil)
        }
        return true
    }

    private static func capture<V: View>(_ view: V, name: String, size: NSSize, appearance: NSAppearance.Name, directory: URL) async throws {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Fan Control · Preview"
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        if name == "settings" && !window.collectionBehavior.contains(.moveToActiveSpace) {
            throw ControlError.invalidConfiguration
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        window.close()
    }
}
#endif
