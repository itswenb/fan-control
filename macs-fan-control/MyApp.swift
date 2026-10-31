import AppKit
import Combine
import CoreText
import QuartzCore
import SwiftUI

@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @State private var store: AppStore
    @StateObject private var updater = AppUpdater()

    init() {
        #if DEBUG
        let store = UIInspection.isRequested ? UIInspection.makeStore() : AppStore()
        _updater = StateObject(wrappedValue: AppUpdater(startingUpdater: !UIInspection.isRequested && !ProcessInfo.processInfo.arguments.contains("--capture-preview")))
        #else
        let store = AppStore()
        #endif
        _store = State(initialValue: store)
        AppLifecycle.store = store
    }

    var body: some Scene {
        Window("Fan Control", id: "main") {
            ContentView().environment(store).environmentObject(updater).tint(.accentColor)
                #if DEBUG
                .background(UIInspection())
                #endif
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            FanControlCommands(store: store, updater: updater)
        }
        MenuBarExtra { MenuBarView().environment(store).environmentObject(updater) } label: {
            MenuBarStatusLabel().environment(store)
        }.menuBarExtraStyle(.window)
        Settings { SettingsView().environment(store).environmentObject(updater) }
    }
}

private struct FanControlCommands: Commands {
    let store: AppStore
    @ObservedObject var updater: AppUpdater

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .appInfo) {
            Button(store.text("检查更新…", "Check for Updates…")) { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        CommandGroup(after: .saveItem) {
            Button(store.text("保存当前预设…", "Save current preset…")) { store.showSavePreset = true }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(store.hardwareOverview?.hasFans != true || store.configurationError != nil)
        }
    }
}

struct MenuBarStatusLabel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var overlay = MenuIconOverlay()
    @State private var overlayInstalled = false

    var body: some View {
        let lines = store.menuLines
        let showIcon = lines.isEmpty || store.settings.showMenuIcon
        let speed = showIcon && store.settings.animateMenuIcon ? store.menuFanSpeed : 0
        let config = MenuIconOverlay.Configuration(showIcon: showIcon, speed: (speed * 20).rounded() / 20,
                                                    sleepOn: store.sleepControl.isOn, dark: colorScheme == .dark)
        Image(nsImage: MenuBarStatusArtwork.make(lines: lines, showIcon: showIcon,
              angle: 0, sleepOn: config.sleepOn, dark: config.dark, drawIcon: !overlayInstalled))
            .interpolation(.high)
            .accessibilityLabel((["Fan Control"] + lines + (store.sleepControl.isOn ? [store.text("禁止休眠已开启", "Sleep prevention on")] : [])).joined(separator: " · "))
            .task(id: config) {
                for _ in 0..<12 {
                    guard !Task.isCancelled else { return }
                    if overlay.configure(config) {
                        overlayInstalled = config.showIcon
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
            }
    }
}

/// 菜单内容仍由 SwiftUI 管理；旋转交给系统合成，避免逐帧重建菜单。 / Keep the menu in SwiftUI and composite rotation independently.
@MainActor
private final class MenuIconOverlay {
    struct Configuration: Equatable { let showIcon: Bool; let speed: Double; let sleepOn: Bool; let dark: Bool }
    private weak var button: NSStatusBarButton?
    private let root = CALayer()
    private let fan = CALayer()
    private let badge = CALayer()
    private var currentSpeed: Double = -1

    init() {
        root.name = "com.itswenb.fancontrol.menu-icon"
        root.frame = CGRect(x: 0, y: 0, width: 24, height: 22)
        fan.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        fan.position = CGPoint(x: 11, y: 11)
        let mask = CALayer()
        mask.frame = fan.bounds
        mask.contents = MenuBarStatusArtwork.fanSymbol
        fan.mask = mask
        root.addSublayer(fan)
        // 状态栏按钮的图层坐标向下增长，保留右下角对齐。 / The status button's layer coordinates grow downward; keep the badge bottom-right.
        badge.frame = CGRect(x: 12, y: 12, width: 9, height: 9)
        badge.contents = MenuBarStatusArtwork.badgeImage
        root.addSublayer(badge)
    }

    func configure(_ config: Configuration) -> Bool {
        func findButton(_ view: NSView) -> NSStatusBarButton? {
            if let button = view as? NSStatusBarButton { return button }
            return view.subviews.lazy.compactMap { findButton($0) }.first
        }
        let candidates = NSApp.windows.compactMap { $0.contentView.flatMap(findButton) }
        guard candidates.count == 1, let target = candidates.first else { return false }
        if button !== target || root.superlayer == nil {
            root.removeFromSuperlayer()
            target.wantsLayer = true
            guard let layer = target.layer else { return false }
            layer.sublayers?.filter { $0 !== root && $0.name == root.name }.forEach { $0.removeFromSuperlayer() }
            layer.addSublayer(root)
            button = target
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.isHidden = !config.showIcon
        badge.isHidden = !config.sleepOn
        fan.backgroundColor = target.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.cgColor : NSColor.black.cgColor
        CATransaction.commit()
        let speed = config.showIcon ? config.speed : 0
        if speed != currentSpeed {
            let phase = (fan.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? 0
            fan.removeAnimation(forKey: "rotation")
            if speed > 0 {
                let duration = 2 / speed
                let count = max(1, Int((duration * 30).rounded()))
                let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                rotation.values = (0...count).map { phase + Double($0) / Double(count) * 2 * .pi }
                rotation.duration = duration
                rotation.calculationMode = .discrete
                rotation.repeatCount = .infinity
                fan.add(rotation, forKey: "rotation")
            }
            currentSpeed = speed
        }
        return true
    }
}

/// MenuBarExtra 会把复杂标签压成单行；预绘制内容可保持系统菜单栏内的两行排版。
@MainActor
enum MenuBarStatusArtwork {
    private struct FrameKey: Hashable {
        let lines: [String]
        let showIcon: Bool
        let angle: Double
        let sleepOn: Bool
        let dark: Bool
        let drawIcon: Bool
    }
    private static var frames: [FrameKey: NSImage] = [:]
    private struct TextKey: Hashable { let lines: [String]; let white: Bool }
    private struct TextLayout { let font: NSFont; let lines: [CTLine]; let widths: [Double] }
    private static var textLayouts: [TextKey: TextLayout] = [:]
    fileprivate static let fanSymbol = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))?
        .cgImage(forProposedRect: nil, context: nil, hints: nil)
    private static let sleepBadge = NSImage(systemSymbolName: "infinity.circle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))?
        .cgImage(forProposedRect: nil, context: nil, hints: nil)
    fileprivate static let badgeImage: CGImage? = {
        guard let sleepBadge, let bitmap = CGContext(data: nil, width: 18, height: 18, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.scaleBy(x: 2, y: 2)
        bitmap.setFillColor(NSColor.white.cgColor)
        bitmap.fillEllipse(in: CGRect(x: 1, y: 1, width: 7, height: 7))
        bitmap.saveGState()
        bitmap.clip(to: CGRect(x: 0, y: 0, width: 9, height: 9), mask: sleepBadge)
        bitmap.setFillColor(NSColor.systemRed.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 9, height: 9))
        bitmap.restoreGState()
        return bitmap.makeImage()
    }()

    static func make(lines: [String], showIcon: Bool, angle: Double, sleepOn: Bool, dark: Bool, drawIcon: Bool = true) -> NSImage {
        let key = FrameKey(lines: lines, showIcon: showIcon, angle: showIcon ? angle : 0, sleepOn: sleepOn, dark: dark, drawIcon: drawIcon)
        if let frame = frames[key] { return frame }
        let textKey = TextKey(lines: lines, white: sleepOn && dark)
        let layout: TextLayout
        if let cached = textLayouts[textKey] { layout = cached }
        else {
            let font = NSFont.monospacedDigitSystemFont(ofSize: lines.count == 2 ? 9 : 12, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: textKey.white ? 1 : 0, alpha: 1)]
            let textLines = lines.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }
            layout = TextLayout(font: font, lines: textLines, widths: textLines.map { ceil(CTLineGetTypographicBounds($0, nil, nil, nil)) })
            if textLayouts.count >= 8 { textLayouts.removeAll(keepingCapacity: true) }
            textLayouts[textKey] = layout
        }
        let font = layout.font, textLines = layout.lines, widths = layout.widths
        let textWidth = widths.max() ?? 0
        let textX: CGFloat = showIcon ? 24 : 2
        let size = NSSize(width: lines.isEmpty ? 24 : textX + textWidth + 2, height: 22)
        // 将当前内容一次性绘制成 Retina 位图，避免菜单栏重绘时再次执行文字及图标绘制。
        let scale: CGFloat = 2
        guard let bitmap = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                     bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(size: size)
        }
        bitmap.scaleBy(x: scale, y: scale)
        // 直接绘制到独立 CGContext，不切换 AppKit 当前上下文或翻转其坐标系。
        if showIcon, drawIcon, let fanSymbol {
            bitmap.saveGState()
            bitmap.translateBy(x: 11, y: 11)
            bitmap.rotate(by: angle)
            bitmap.clip(to: CGRect(x: -9, y: -9, width: 18, height: 18), mask: fanSymbol)
            bitmap.setFillColor(CGColor(gray: sleepOn && dark ? 1 : 0, alpha: 1))
            bitmap.fill(CGRect(x: -9, y: -9, width: 18, height: 18))
            bitmap.restoreGState()
            if sleepOn, let badge = sleepBadge {
                let rect = CGRect(x: 12, y: 1, width: 9, height: 9)
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
                bitmap.fillEllipse(in: rect.insetBy(dx: 1, dy: 1))
                bitmap.saveGState()
                bitmap.clip(to: rect, mask: badge)
                bitmap.setFillColor(NSColor.systemRed.cgColor)
                bitmap.fill(rect)
                bitmap.restoreGState()
            }
        }
        for (index, line) in textLines.enumerated() {
            let x = textX + (textWidth - widths[index]) / 2
            let top: CGFloat = lines.count == 2 ? (index == 0 ? 0 : 11) : 3
            bitmap.textPosition = CGPoint(x: x, y: size.height - top - font.ascender)
            CTLineDraw(line, bitmap)
        }
        guard let raster = bitmap.makeImage() else { return NSImage(size: size) }
        let image = NSImage(cgImage: raster, size: size)
        image.isTemplate = !sleepOn
        if frames.count >= 32 { frames.removeAll(keepingCapacity: true) }
        frames[key] = image
        return image
    }
}

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    static var store: AppStore?
    private var terminating = false
    private var terminationApproved = false
    private let windows = AppWindowVisibility()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DebugPreview.captureIfRequested() { return }
        #endif
        Self.store?.start()
        windows.onVisibilityChange = { Self.store?.setDetailedMonitoring($0) }
        windows.start()
        #if DEBUG
        if UIInspection.isRequested {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { UIInspection.describeWindowsIfRequested() }
        }
        #endif
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        if UIInspection.isRequested { return .terminateNow }
        #endif
        if terminationApproved { return .terminateNow }
        guard let store = Self.store,
              store.hasCustomControl || store.recoveryUnconfirmed || store.controlPending || store.sleepControl.needsRelease else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        Task {
            do {
                try await store.restoreForTermination()
                terminationApproved = true
                sender.terminate(nil)
            } catch {
                sender.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = store.text("系统设置恢复尚未确认", "System settings recovery has not been confirmed")
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
    func applicationWillTerminate(_ notification: Notification) { windows.stop(); Self.store?.stop() }
    @objc private func willSleep() { Self.store?.suspend() }
    @objc private func didWake() { Self.store?.resume() }
}
