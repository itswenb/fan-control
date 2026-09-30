import AppKit
import SwiftUI

@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @State private var store: AppStore

    init() {
        let store = AppStore()
        _store = State(initialValue: store)
        AppLifecycle.store = store
    }

    var body: some Scene {
        Window("Fan Control", id: "main") {
            ContentView().environment(store).tint(.accentColor)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button(store.text("保存当前预设…", "Save current preset…")) { store.showSavePreset = true }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(store.snapshot?.fans.isEmpty != false || store.configurationError != nil)
            }
        }
        MenuBarExtra { MenuBarView().environment(store) } label: {
            MenuBarStatusLabel().environment(store)
        }.menuBarExtraStyle(.window)
        Settings { SettingsView().environment(store) }
    }
}

struct MenuBarStatusLabel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let lines = store.menuLines
        if lines.isEmpty {
            Image(systemName: "fan.fill")
                .font(.system(size: 12))
                .accessibilityLabel("Fan Control")
        } else {
            Image(nsImage: MenuBarStatusArtwork.make(lines: lines, showIcon: store.settings.showMenuIcon))
                .interpolation(.high)
                .accessibilityLabel("Fan Control · " + lines.joined(separator: " · "))
        }
    }
}

/// MenuBarExtra 会把复杂标签压成单行；预绘制内容可保持系统菜单栏内的两行排版。
enum MenuBarStatusArtwork {
    static func make(lines: [String], showIcon: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: lines.count == 2 ? 9 : 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let widths = lines.map { ceil(($0 as NSString).size(withAttributes: attributes).width) }
        let textWidth = widths.max() ?? 0
        let textX: CGFloat = showIcon ? 20 : 2
        let size = NSSize(width: textX + textWidth + 2, height: 22)
        let image = NSImage(size: size, flipped: true) { _ in
            if showIcon, let symbol = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
                symbol.draw(in: NSRect(x: 2, y: 4, width: 14, height: 14))
            }
            for (index, line) in lines.enumerated() {
                let x = textX + (textWidth - widths[index]) / 2
                let y: CGFloat = lines.count == 2 ? (index == 0 ? 0 : 11) : 3
                (line as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    static var store: AppStore?
    private var terminating = false
    private var terminationApproved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DebugPreview.captureIfRequested() { return }
        #endif
        Self.store?.start()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationApproved { return .terminateNow }
        guard let store = Self.store,
              store.hasCustomControl || store.recoveryUnconfirmed || store.controlPending else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        Task {
            do {
                try await store.restoreHardware()
                terminationApproved = true
                sender.terminate(nil)
            } catch {
                sender.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = store.text("恢复系统自动尚未确认", "Automatic mode has not been confirmed")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: store.text("留在应用中重试", "Stay and retry"))
                alert.addButton(withTitle: store.text("仍然退出", "Quit anyway"))
                let force = alert.runModal() == .alertSecondButtonReturn
                terminating = false
                if force {
                    terminationApproved = true
                    sender.terminate(nil)
                }
            }
        }
        // 先退出当前事件处理，再异步恢复；避免菜单栏操作被 AppKit 的模态退出循环卡住。
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { Self.store?.stop() }
    @objc private func willSleep() { Self.store?.suspend() }
    @objc private func didWake() { Self.store?.resume() }
}
